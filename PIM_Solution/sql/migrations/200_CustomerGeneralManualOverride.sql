/*
  200 - rocna prilagoditev splosnih podatkov stranke (Splosni podatki, /stranke/{id}).

  Uporabnik 2026-09-14: na kartici stranke, zavihek "Splosni podatki", je bilo vseh ~25 polj
  (naziv, naslov, davcna stevilka, cenik, jezik, placilni rok ...) samo za branje, ker gredo
  neposredno iz b2b.Customer - tabele, ki jo prek zajema piše SAOP. Ce bi PIM pisal direktno vanjo,
  bi jo naslednja sinhronizacija SAOP tiho povozila nazaj.

  Resitev je isti vzorec kot za kontakte stranke (migracija 140, pim.CustomerContact /
  b2b.SaveCustomerContact): nova tabela pim.CustomerGeneralOverride nosi samo rocni prepis,
  intranet.GetCustomerCard pa v prvem naboru vrne COALESCE(override, izvor) - rocna vrednost
  prevlada, dokler obstaja; ce je rocna vrednost enaka trenutnemu izvoru, se ob shranjevanju ne
  zapise kot prepis (isto pravilo kot pri kontaktih), da SAOP lahko svoj podatek se vedno popravi.
  Sifra dejavnosti stranke (CustomerKey) je namenoma vkljucena med urejljiva polja na izrecno
  zahtevo uporabnika, kljub opozorilu, da SAOP z njo ujema zapise - ce se rocno spremeni, jo
  naslednja sinhronizacija morda ne bo vec prepoznala kot isto stranko.

  Vsaka sprememba gre v b2b.AuditLog (EntityType='CustomerGeneral') - to je isti vir, ki ga
  zavihek "Zgodovina sprememb" ze bere (migracija 129), zato ni potreben noben poseg tam.
*/

SET XACT_ABORT ON;

IF OBJECT_ID(N'pim.CustomerGeneralOverride', N'U') IS NULL
CREATE TABLE pim.CustomerGeneralOverride
(
  OrganizationId int NOT NULL,
  CustomerId bigint NOT NULL,
  CustomerKey nvarchar(100) NULL,
  Name nvarchar(300) NULL,
  PayerCode nvarchar(100) NULL,
  PayerName nvarchar(300) NULL,
  PriceListCode nvarchar(100) NULL,
  DiscountPriceListCode nvarchar(100) NULL,
  Address nvarchar(400) NULL,
  Street nvarchar(400) NULL,
  HouseNumber nvarchar(60) NULL,
  City nvarchar(200) NULL,
  PostalCode nvarchar(40) NULL,
  Country nvarchar(20) NULL,
  TaxNumber nvarchar(40) NULL,
  RegistrationNumber nvarchar(40) NULL,
  ActivityCode nvarchar(40) NULL,
  SubjectToVat bit NULL,
  PaymentDays int NULL,
  RebatePercent decimal(9,4) NULL,
  IsActive bit NULL,
  CustomerType nvarchar(10) NULL,
  LegalForm nvarchar(10) NULL,
  IsDefaulter bit NULL,
  UpfrontPayment bit NULL,
  LanguageId nvarchar(20) NULL,
  CurrencyCode nvarchar(20) NULL,
  UpdatedBy nvarchar(200) NOT NULL,
  UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_CustomerGeneralOverride_Updated DEFAULT SYSUTCDATETIME(),
  CONSTRAINT PK_CustomerGeneralOverride PRIMARY KEY (OrganizationId, CustomerId),
  CONSTRAINT FK_CustomerGeneralOverride_Customer FOREIGN KEY (CustomerId) REFERENCES b2b.Customer(CustomerId)
);

EXEC(N'
CREATE OR ALTER PROCEDURE b2b.SaveCustomerGeneral
  @OrganizationId int,
  @CustomerId bigint,
  @CustomerKey nvarchar(100) = NULL,
  @Name nvarchar(300) = NULL,
  @PayerCode nvarchar(100) = NULL,
  @PayerName nvarchar(300) = NULL,
  @PriceListCode nvarchar(100) = NULL,
  @DiscountPriceListCode nvarchar(100) = NULL,
  @Address nvarchar(400) = NULL,
  @Street nvarchar(400) = NULL,
  @HouseNumber nvarchar(60) = NULL,
  @City nvarchar(200) = NULL,
  @PostalCode nvarchar(40) = NULL,
  @Country nvarchar(20) = NULL,
  @TaxNumber nvarchar(40) = NULL,
  @RegistrationNumber nvarchar(40) = NULL,
  @ActivityCode nvarchar(40) = NULL,
  @SubjectToVat bit = NULL,
  @PaymentDays int = NULL,
  @RebatePercent decimal(9,4) = NULL,
  @IsActive bit = NULL,
  @CustomerType nvarchar(10) = NULL,
  @LegalForm nvarchar(10) = NULL,
  @IsDefaulter bit = NULL,
  @UpfrontPayment bit = NULL,
  @LanguageId nvarchar(20) = NULL,
  @CurrencyCode nvarchar(20) = NULL,
  @ChangedBy nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  BEGIN TRAN;

  IF NOT EXISTS (SELECT 1 FROM b2b.Customer WHERE CustomerId = @CustomerId AND OrganizationId = @OrganizationId)
    THROW 52001, N''Stranka ne obstaja.'', 1;

  -- Prazen niz pomeni ''ni rocnega prepisa'', enako pravilo kot pri kontaktih.
  SET @CustomerKey = NULLIF(LTRIM(RTRIM(@CustomerKey)), N'''');
  SET @Name = NULLIF(LTRIM(RTRIM(@Name)), N'''');
  SET @PayerCode = NULLIF(LTRIM(RTRIM(@PayerCode)), N'''');
  SET @PayerName = NULLIF(LTRIM(RTRIM(@PayerName)), N'''');
  SET @PriceListCode = NULLIF(LTRIM(RTRIM(@PriceListCode)), N'''');
  SET @DiscountPriceListCode = NULLIF(LTRIM(RTRIM(@DiscountPriceListCode)), N'''');
  SET @Address = NULLIF(LTRIM(RTRIM(@Address)), N'''');
  SET @Street = NULLIF(LTRIM(RTRIM(@Street)), N'''');
  SET @HouseNumber = NULLIF(LTRIM(RTRIM(@HouseNumber)), N'''');
  SET @City = NULLIF(LTRIM(RTRIM(@City)), N'''');
  SET @PostalCode = NULLIF(LTRIM(RTRIM(@PostalCode)), N'''');
  SET @Country = NULLIF(LTRIM(RTRIM(@Country)), N'''');
  SET @TaxNumber = NULLIF(LTRIM(RTRIM(@TaxNumber)), N'''');
  SET @RegistrationNumber = NULLIF(LTRIM(RTRIM(@RegistrationNumber)), N'''');
  SET @ActivityCode = NULLIF(LTRIM(RTRIM(@ActivityCode)), N'''');
  SET @CustomerType = NULLIF(LTRIM(RTRIM(@CustomerType)), N'''');
  SET @LegalForm = NULLIF(LTRIM(RTRIM(@LegalForm)), N'''');
  SET @LanguageId = NULLIF(LTRIM(RTRIM(@LanguageId)), N'''');
  SET @CurrencyCode = NULLIF(LTRIM(RTRIM(@CurrencyCode)), N'''');

  -- Trenutna vrednost iz SAOP (b2b.Customer), da rocna vrednost, enaka izvoru, ni prepis --
  -- sicer bi krog izvoz->uvoz rocni prepis zabetoniral in izvor ne bi mogel vec nicesar popraviti.
  DECLARE @SrcCustomerKey nvarchar(100);
  DECLARE @SrcName nvarchar(300);
  DECLARE @SrcPayerCode nvarchar(100);
  DECLARE @SrcPayerName nvarchar(300);
  DECLARE @SrcPriceListCode nvarchar(100);
  DECLARE @SrcDiscountPriceListCode nvarchar(100);
  DECLARE @SrcAddress nvarchar(400);
  DECLARE @SrcStreet nvarchar(400);
  DECLARE @SrcHouseNumber nvarchar(60);
  DECLARE @SrcCity nvarchar(200);
  DECLARE @SrcPostalCode nvarchar(40);
  DECLARE @SrcCountry nvarchar(20);
  DECLARE @SrcTaxNumber nvarchar(40);
  DECLARE @SrcRegistrationNumber nvarchar(40);
  DECLARE @SrcActivityCode nvarchar(40);
  DECLARE @SrcSubjectToVat bit;
  DECLARE @SrcPaymentDays int;
  DECLARE @SrcRebatePercent decimal(9,4);
  DECLARE @SrcIsActive bit;
  DECLARE @SrcCustomerType nvarchar(10);
  DECLARE @SrcLegalForm nvarchar(10);
  DECLARE @SrcIsDefaulter bit;
  DECLARE @SrcUpfrontPayment bit;
  DECLARE @SrcLanguageId nvarchar(20);
  DECLARE @SrcCurrencyCode nvarchar(20);
  SELECT
    @SrcCustomerKey = customer.CustomerKey,
    @SrcName = customer.Name,
    @SrcPayerCode = customer.PayerCode,
    @SrcPayerName = customer.PayerName,
    @SrcPriceListCode = customer.PriceListCode,
    @SrcDiscountPriceListCode = customer.DiscountPriceListCode,
    @SrcAddress = customer.Address,
    @SrcStreet = customer.Street,
    @SrcHouseNumber = customer.HouseNumber,
    @SrcCity = customer.City,
    @SrcPostalCode = customer.PostalCode,
    @SrcCountry = customer.Country,
    @SrcTaxNumber = customer.TaxNumber,
    @SrcRegistrationNumber = customer.RegistrationNumber,
    @SrcActivityCode = customer.ActivityCode,
    @SrcSubjectToVat = customer.SubjectToVat,
    @SrcPaymentDays = customer.PaymentDays,
    @SrcRebatePercent = customer.RebatePercent,
    @SrcIsActive = customer.IsActive,
    @SrcCustomerType = customer.CustomerType,
    @SrcLegalForm = customer.LegalForm,
    @SrcIsDefaulter = customer.IsDefaulter,
    @SrcUpfrontPayment = customer.UpfrontPayment,
    @SrcLanguageId = customer.LanguageId,
    @SrcCurrencyCode = customer.CurrencyCode
  FROM b2b.Customer AS customer
  WHERE customer.CustomerId = @CustomerId AND customer.OrganizationId = @OrganizationId;

  IF @CustomerKey = @SrcCustomerKey OR (@CustomerKey IS NULL AND @SrcCustomerKey IS NULL) SET @CustomerKey = NULL;
  IF @Name = @SrcName OR (@Name IS NULL AND @SrcName IS NULL) SET @Name = NULL;
  IF @PayerCode = @SrcPayerCode OR (@PayerCode IS NULL AND @SrcPayerCode IS NULL) SET @PayerCode = NULL;
  IF @PayerName = @SrcPayerName OR (@PayerName IS NULL AND @SrcPayerName IS NULL) SET @PayerName = NULL;
  IF @PriceListCode = @SrcPriceListCode OR (@PriceListCode IS NULL AND @SrcPriceListCode IS NULL) SET @PriceListCode = NULL;
  IF @DiscountPriceListCode = @SrcDiscountPriceListCode OR (@DiscountPriceListCode IS NULL AND @SrcDiscountPriceListCode IS NULL) SET @DiscountPriceListCode = NULL;
  IF @Address = @SrcAddress OR (@Address IS NULL AND @SrcAddress IS NULL) SET @Address = NULL;
  IF @Street = @SrcStreet OR (@Street IS NULL AND @SrcStreet IS NULL) SET @Street = NULL;
  IF @HouseNumber = @SrcHouseNumber OR (@HouseNumber IS NULL AND @SrcHouseNumber IS NULL) SET @HouseNumber = NULL;
  IF @City = @SrcCity OR (@City IS NULL AND @SrcCity IS NULL) SET @City = NULL;
  IF @PostalCode = @SrcPostalCode OR (@PostalCode IS NULL AND @SrcPostalCode IS NULL) SET @PostalCode = NULL;
  IF @Country = @SrcCountry OR (@Country IS NULL AND @SrcCountry IS NULL) SET @Country = NULL;
  IF @TaxNumber = @SrcTaxNumber OR (@TaxNumber IS NULL AND @SrcTaxNumber IS NULL) SET @TaxNumber = NULL;
  IF @RegistrationNumber = @SrcRegistrationNumber OR (@RegistrationNumber IS NULL AND @SrcRegistrationNumber IS NULL) SET @RegistrationNumber = NULL;
  IF @ActivityCode = @SrcActivityCode OR (@ActivityCode IS NULL AND @SrcActivityCode IS NULL) SET @ActivityCode = NULL;
  IF @SubjectToVat = @SrcSubjectToVat OR (@SubjectToVat IS NULL AND @SrcSubjectToVat IS NULL) SET @SubjectToVat = NULL;
  IF @PaymentDays = @SrcPaymentDays OR (@PaymentDays IS NULL AND @SrcPaymentDays IS NULL) SET @PaymentDays = NULL;
  IF @RebatePercent = @SrcRebatePercent OR (@RebatePercent IS NULL AND @SrcRebatePercent IS NULL) SET @RebatePercent = NULL;
  IF @IsActive = @SrcIsActive OR (@IsActive IS NULL AND @SrcIsActive IS NULL) SET @IsActive = NULL;
  IF @CustomerType = @SrcCustomerType OR (@CustomerType IS NULL AND @SrcCustomerType IS NULL) SET @CustomerType = NULL;
  IF @LegalForm = @SrcLegalForm OR (@LegalForm IS NULL AND @SrcLegalForm IS NULL) SET @LegalForm = NULL;
  IF @IsDefaulter = @SrcIsDefaulter OR (@IsDefaulter IS NULL AND @SrcIsDefaulter IS NULL) SET @IsDefaulter = NULL;
  IF @UpfrontPayment = @SrcUpfrontPayment OR (@UpfrontPayment IS NULL AND @SrcUpfrontPayment IS NULL) SET @UpfrontPayment = NULL;
  IF @LanguageId = @SrcLanguageId OR (@LanguageId IS NULL AND @SrcLanguageId IS NULL) SET @LanguageId = NULL;
  IF @CurrencyCode = @SrcCurrencyCode OR (@CurrencyCode IS NULL AND @SrcCurrencyCode IS NULL) SET @CurrencyCode = NULL;

  DECLARE @old nvarchar(max) =
    (SELECT * FROM pim.CustomerGeneralOverride WHERE OrganizationId = @OrganizationId AND CustomerId = @CustomerId
     FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

  -- Vrstica ostane tudi, ko so vsa polja prazna: to je ''pocisti rocne prilagoditve'', ne brisanje.
  MERGE pim.CustomerGeneralOverride AS target
  USING (SELECT @OrganizationId AS OrganizationId, @CustomerId AS CustomerId) AS source
    ON target.OrganizationId = source.OrganizationId AND target.CustomerId = source.CustomerId
  WHEN MATCHED THEN UPDATE SET
    CustomerKey = @CustomerKey,
    Name = @Name,
    PayerCode = @PayerCode,
    PayerName = @PayerName,
    PriceListCode = @PriceListCode,
    DiscountPriceListCode = @DiscountPriceListCode,
    Address = @Address,
    Street = @Street,
    HouseNumber = @HouseNumber,
    City = @City,
    PostalCode = @PostalCode,
    Country = @Country,
    TaxNumber = @TaxNumber,
    RegistrationNumber = @RegistrationNumber,
    ActivityCode = @ActivityCode,
    SubjectToVat = @SubjectToVat,
    PaymentDays = @PaymentDays,
    RebatePercent = @RebatePercent,
    IsActive = @IsActive,
    CustomerType = @CustomerType,
    LegalForm = @LegalForm,
    IsDefaulter = @IsDefaulter,
    UpfrontPayment = @UpfrontPayment,
    LanguageId = @LanguageId,
    CurrencyCode = @CurrencyCode,
    UpdatedBy = @ChangedBy, UpdatedUtc = SYSUTCDATETIME()
  WHEN NOT MATCHED THEN
    INSERT (OrganizationId, CustomerId, CustomerKey, Name, PayerCode, PayerName, PriceListCode, DiscountPriceListCode, Address, Street, HouseNumber, City, PostalCode, Country, TaxNumber, RegistrationNumber, ActivityCode, SubjectToVat, PaymentDays, RebatePercent, IsActive, CustomerType, LegalForm, IsDefaulter, UpfrontPayment, LanguageId, CurrencyCode, UpdatedBy)
    VALUES (@OrganizationId, @CustomerId, @CustomerKey, @Name, @PayerCode, @PayerName, @PriceListCode, @DiscountPriceListCode, @Address, @Street, @HouseNumber, @City, @PostalCode, @Country, @TaxNumber, @RegistrationNumber, @ActivityCode, @SubjectToVat, @PaymentDays, @RebatePercent, @IsActive, @CustomerType, @LegalForm, @IsDefaulter, @UpfrontPayment, @LanguageId, @CurrencyCode, @ChangedBy);

  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy)
  SELECT @OrganizationId, N''CustomerGeneral'', CONVERT(nvarchar(200), @CustomerId), N''UPSERT'', @old,
    (SELECT * FROM pim.CustomerGeneralOverride WHERE OrganizationId = @OrganizationId AND CustomerId = @CustomerId
     FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
    @ChangedBy;

  COMMIT;
END;
');

EXEC(N'

CREATE OR ALTER PROCEDURE intranet.GetCustomerCard
  @OrganizationId int,
  @CustomerId bigint
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @CustomerKey nvarchar(200) = (
    SELECT customer.CustomerKey FROM b2b.Customer AS customer
    WHERE customer.OrganizationId = @OrganizationId AND customer.CustomerId = @CustomerId);

  /* 1 - splosni podatki: kar je prislo iz SAOP, in profil, ki je last PIM. */
  SELECT customer.CustomerId,
    CustomerKey = COALESCE(override.CustomerKey, customer.CustomerKey),
    Name = COALESCE(override.Name, customer.Name),
    PayerCode = COALESCE(override.PayerCode, customer.PayerCode),
    PayerName = COALESCE(override.PayerName, customer.PayerName),
    PriceListCode = COALESCE(override.PriceListCode, customer.PriceListCode),
    DiscountPriceListCode = COALESCE(override.DiscountPriceListCode, customer.DiscountPriceListCode),
    Address = COALESCE(override.Address, customer.Address),
    Street = COALESCE(override.Street, customer.Street),
    HouseNumber = COALESCE(override.HouseNumber, customer.HouseNumber),
    City = COALESCE(override.City, customer.City),
    PostalCode = COALESCE(override.PostalCode, customer.PostalCode),
    Country = COALESCE(override.Country, customer.Country),
    TaxNumber = COALESCE(override.TaxNumber, customer.TaxNumber),
    RegistrationNumber = COALESCE(override.RegistrationNumber, customer.RegistrationNumber),
    ActivityCode = COALESCE(override.ActivityCode, customer.ActivityCode),
    SubjectToVat = COALESCE(override.SubjectToVat, customer.SubjectToVat),
    PaymentDays = COALESCE(override.PaymentDays, customer.PaymentDays),
    RebatePercent = COALESCE(override.RebatePercent, customer.RebatePercent),
    IsActive = COALESCE(override.IsActive, customer.IsActive),
    LegalForm = COALESCE(override.LegalForm, customer.LegalForm),
    IsDefaulter = COALESCE(override.IsDefaulter, customer.IsDefaulter),
    UpfrontPayment = COALESCE(override.UpfrontPayment, customer.UpfrontPayment),
    LanguageId = COALESCE(override.LanguageId, customer.LanguageId),
    CurrencyCode = COALESCE(override.CurrencyCode, customer.CurrencyCode),
    SourceCustomerType = COALESCE(override.CustomerType, customer.CustomerType),
    customer.UpdatedUtc,
    profileValue.CustomerTypeCode, profileValue.CustomerKind, profileValue.PayerKind,
    PackagingDiscountEnabled = COALESCE(profileValue.PackagingDiscountEnabled, CONVERT(bit, 0)),
    ValueDiscountEnabled = COALESCE(profileValue.ValueDiscountEnabled, CONVERT(bit, 0)),
    B2bPlusEnabled = COALESCE(profileValue.B2bPlusEnabled, CONVERT(bit, 0)),
    profileValue.B2bPlusValidFrom, profileValue.B2bPlusValidTo,
    WebEnabled = COALESCE(profileValue.WebEnabled, CONVERT(bit, 0)),
    MagentoGroupKey = magentoGroup.MagentoGroupKey,
    CustomerTypeName = typeCatalog.Name,
    HasManualGeneral = CONVERT(bit, CASE WHEN override.CustomerId IS NULL THEN 0 ELSE 1 END),
    GeneralUpdatedBy = override.UpdatedBy,
    GeneralUpdatedUtc = override.UpdatedUtc
  FROM b2b.Customer AS customer
  LEFT JOIN pim.CustomerGeneralOverride AS override
    ON override.OrganizationId = customer.OrganizationId AND override.CustomerId = customer.CustomerId
  LEFT JOIN pim.CustomerWebProfile AS profileValue ON profileValue.CustomerId = customer.CustomerId
  LEFT JOIN pim.CustomerTypeCatalog AS typeCatalog ON typeCatalog.CustomerTypeCode = profileValue.CustomerTypeCode
  LEFT JOIN pim.CustomerTypeMagentoGroup AS magentoGroup
    ON magentoGroup.CustomerTypeCode = profileValue.CustomerTypeCode AND magentoGroup.IsActive = 1
  WHERE customer.OrganizationId = @OrganizationId AND customer.CustomerId = @CustomerId;

  /* 2 - skupine popustov po skupini artiklov. Nosilna vez je skupina strank (pravila ő4.1),
         zato se berejo po Magento skupini stranke, ne po sifri stranke. */
  SELECT discount.ItemGroupCode, discount.DiscountPercent, discount.MinQuantity,
    discount.ValidFrom, discount.ValidTo, discount.CustomerGroupCode
  FROM b2b.CustomerItemGroupDiscount AS discount
  WHERE discount.OrganizationId = @OrganizationId
    AND discount.CustomerGroupCode IN
    (
      SELECT magentoGroup.MagentoGroupKey
      FROM pim.CustomerWebProfile AS profileValue
      INNER JOIN pim.CustomerTypeMagentoGroup AS magentoGroup
        ON magentoGroup.CustomerTypeCode = profileValue.CustomerTypeCode AND magentoGroup.IsActive = 1
      WHERE profileValue.CustomerId = @CustomerId
    )
  ORDER BY discount.ItemGroupCode;

  /* 3 - vrednostni pragovi stranke. */
  SELECT tier.TierNumber, tier.ThresholdGrossExVat, tier.PercentValue, tier.IsActive
  FROM pim.CustomerValueDiscountTier AS tier
  WHERE tier.CustomerId = @CustomerId
  ORDER BY tier.TierNumber;

  /* 4 - posebni popusti za stranko na posameznem izdelku. */
  SELECT overrideValue.OverrideId, overrideValue.DiscountCode, overrideValue.ValidFrom,
    overrideValue.ValidTo, overrideValue.IsActive,
    ItemID = product.ItemID, ProductName = product.ItemID
  FROM b2b.CustomerPackagingDiscountOverride AS overrideValue
  LEFT JOIN pim.Product AS product ON product.PimProductId = overrideValue.PimProductId
  WHERE overrideValue.CustomerId = @CustomerId
  ORDER BY overrideValue.OverrideId DESC;

  /* 5 - poslovne enote in tranziti. */
  SELECT branch.CustomerBranchId, branch.BranchKind, branch.IsActive, branch.Note,
    branch.CreatedBy, branch.CreatedUtc,
    BranchCustomerId = branch.BranchCustomerId,
    BranchCode = COALESCE(branchCustomer.CustomerKey, branch.BranchCode),
    BranchName = COALESCE(branchCustomer.Name, branch.BranchName),
    FromCatalog = CONVERT(bit, CASE WHEN branch.BranchCustomerId IS NULL THEN 0 ELSE 1 END)
  FROM pim.CustomerBranch AS branch
  LEFT JOIN b2b.Customer AS branchCustomer ON branchCustomer.CustomerId = branch.BranchCustomerId
  WHERE branch.OrganizationId = @OrganizationId AND branch.CustomerId = @CustomerId
  ORDER BY branch.BranchKind, COALESCE(branchCustomer.Name, branch.BranchName);

  /* 6 - zaznamki, najnovejsi zgoraj. */
  SELECT note.CustomerNoteId, note.Body, note.CreatedBy, note.CreatedUtc
  FROM pim.CustomerNote AS note
  WHERE note.OrganizationId = @OrganizationId AND note.CustomerId = @CustomerId
  ORDER BY note.CreatedUtc DESC, note.CustomerNoteId DESC;

  /* 7 - zgodovina sprememb iz obstojece revizijske sledi; nove tabele ni. */
  SELECT auditValue.AuditLogId, auditValue.EntityType, auditValue.ActionCode,
    auditValue.OldValueJson, auditValue.NewValueJson, auditValue.ChangedBy, auditValue.ChangedUtc
  FROM b2b.AuditLog AS auditValue
  WHERE auditValue.OrganizationId = @OrganizationId
    AND auditValue.EntityKey IN (CONVERT(nvarchar(200), @CustomerId), @CustomerKey)
  ORDER BY auditValue.ChangedUtc DESC, auditValue.AuditLogId DESC;

  /* 8 - kontakti. Ucinkovita vrednost je rocni prepis, sicer izvor; znacka pove, kateri
         od obeh je obveljal. Nabor je na koncu, da prvih sedem branj ostane na svojem mestu. */
  DECLARE @SourceEmail nvarchar(400) = NULL,
          @SourcePhone nvarchar(200) = NULL,
          @SourceMobile nvarchar(200) = NULL,
          @SourcePersons nvarchar(1000) = NULL;

  /* Ali zajem kontaktov sploh obstaja, se ne ugiba iz imena tabele, ampak iz registra
     preslikav: ko bo endpoint GetCustomerContacts dobil svoje preslikave s kanonicnimi
     kodami CustomerContact.*, se to samo od sebe prevesi na 1. */
  DECLARE @ContactCaptureExists bit = CONVERT(bit, CASE WHEN EXISTS
  (
    SELECT 1
    FROM map.FieldMapping AS mapping
    INNER JOIN map.SourceConnector AS connector
      ON connector.SourceConnectorId = mapping.SourceConnectorId
    WHERE connector.OrganizationId = @OrganizationId
      AND connector.IsActive = 1 AND mapping.IsActive = 1
      AND mapping.TargetFieldCode LIKE N''CustomerContact.%''
  ) THEN 1 ELSE 0 END);

  SELECT
    Email = COALESCE(manual.Email, @SourceEmail),
    Phone = COALESCE(manual.Phone, @SourcePhone),
    Mobile = COALESCE(manual.Mobile, @SourceMobile),
    Persons = COALESCE(manual.Persons, @SourcePersons),
    EmailSource = CASE WHEN manual.Email IS NOT NULL THEN N''PIM'' WHEN @SourceEmail IS NOT NULL THEN N''SAOP'' END,
    PhoneSource = CASE WHEN manual.Phone IS NOT NULL THEN N''PIM'' WHEN @SourcePhone IS NOT NULL THEN N''SAOP'' END,
    MobileSource = CASE WHEN manual.Mobile IS NOT NULL THEN N''PIM'' WHEN @SourceMobile IS NOT NULL THEN N''SAOP'' END,
    PersonsSource = CASE WHEN manual.Persons IS NOT NULL THEN N''PIM'' WHEN @SourcePersons IS NOT NULL THEN N''SAOP'' END,
    /* Obrazec ureja rocni prepis, ne ucinkovite vrednosti; sicer bi prvo shranjevanje
       posnetek izvora zapisalo kot rocno vrednost. */
    ManualEmail = manual.Email, ManualPhone = manual.Phone,
    ManualMobile = manual.Mobile, ManualPersons = manual.Persons,
    SourceEmail = @SourceEmail, SourcePhone = @SourcePhone,
    SourceMobile = @SourceMobile, SourcePersons = @SourcePersons,
    SourceAvailable = @ContactCaptureExists,
    SourceNote = CASE WHEN @ContactCaptureExists = 1 THEN NULL ELSE
      N''Zajema kontaktov ni: PIM ne klice endpointa GetCustomerContacts, zato zanj ni ne vrstice ''
      + N''v map.EntityMapping ne preslikav CustomerContact.* v map.FieldMapping in ne zapisov v raw.Inbox. ''
      + N''Endpoint GetCustomers, ki ga PIM zajema, kontaktov ne nosi.'' END,
    UpdatedBy = manual.UpdatedBy,
    UpdatedUtc = manual.UpdatedUtc
  FROM (SELECT CustomerId = @CustomerId) AS anchor
  LEFT JOIN pim.CustomerContact AS manual
    ON manual.OrganizationId = @OrganizationId AND manual.CustomerId = anchor.CustomerId;
END;

');

IF OBJECT_ID(N'pim.CustomerGeneralOverride', N'U') IS NULL
  THROW 51501, N'200: pim.CustomerGeneralOverride ni nastala.', 1;
IF OBJECT_ID(N'b2b.SaveCustomerGeneral', N'P') IS NULL
  THROW 51502, N'200: b2b.SaveCustomerGeneral ni nastala.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetCustomerCard')) NOT LIKE N'%CustomerGeneralOverride%'
  THROW 51503, N'200: intranet.GetCustomerCard se ne sklicuje na CustomerGeneralOverride.', 1;
