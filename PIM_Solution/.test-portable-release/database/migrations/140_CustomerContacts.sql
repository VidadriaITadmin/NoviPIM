/*
  140 — kontakti stranke: e-posta, telefon, mobitel in osebe.

  Zakaj: to so obvezni stolpci izvoza strank za Magento, v PIM-u pa jih danes ni nikjer.
  b2b.Customer ima naslov, davcno in placilne pogoje, kontakta pa ne (preverjeno nad
  razvojno bazo PIM 2026-09-02: sys.columns za b2b.Customer nima ne Email ne Phone).

  ZAJEMA KONTAKTOV V NOVIPIM-u NI. Preverjeno nad razvojno bazo:
    - map.EntityMapping pozna 21 entitet; med njimi ni nobene s kontakti
      (Customers, CustomerItemGroupDiscounts, ItemGeneralData, Prices ...);
    - map.FieldMapping nima nobene preslikave z elementom Mail/Phone/Telefon;
    - raw.Inbox nima nobene vrstice z EntityType, ki bi nosil kontakte;
    - vsebina zajetega zapisa Customers (endpoint GetCustomers, zapis
      /ArrayOfCustomer/Customer) kontaktov sploh ne nosi — ima Code, Name, Address,
      Country, PostalCode, City, TaxAccounting, CustomerType in placilne pogoje.
      Kontakti so v SAOP v locenem endpointu GetCustomerContacts, ki ga PIM ne klice.

  Zato ta migracija naredi tisto, kar je mogoce narediti pošteno:

    1. Rocni vnos dobi svojo tabelo pim.CustomerContact in svojo pisljivo pot.
       Rocna vrednost je uporabna tudi brez izvora — izvoz za Magento jo potrebuje danes.
    2. Bralni model pove, ali izvor obstaja, in ce ne, natanko pove, kaj manjka.
       Vmesnik iz tega narisi <PimMissing>, ne prazne tabele.
    3. Pravilo »rocna vrednost, enaka izvoru, se ne shrani kot prepis« je zapisano v
       proceduri, ne v vmesniku. Ko zajem pride, pravilo ze velja in ga ni treba dodajati.
       Brez njega bi vsak krog izvoz -> uvoz zabetoniral posnetek izvora kot rocni prepis.

  Kaj ta migracija NAMENOMA NE naredi:
    - Ne izmislja si zajema kontaktov. Nobenega konektorja, entitete ali preslikave,
      ki ne bi imela zaledja, ne doda; prazna preslikava bi bila lazna obljuba.
    - Ne spreminja out.OwnershipPolicy. Kontakti se v SAOP ne pisejo nazaj; ce se bo to
      kdaj zahtevalo, je to poslovna odlocitev iz preglednice Mapiranje_SAOP_API_PIM.xlsx.

  Osmi nabor je dodan NA KONEC intranet.GetCustomerCard, da obstojecih sedem branj v
  CustomerCardService ne premakne. Procedura je prepisana v celoti, ker T-SQL nima nacina,
  da bi obstojeci proceduri dodal en sam SELECT.

  Migrator ne pozna locila GO; procedure so zavite v EXEC(N'...') kot v 020, 081 in 129.
*/

SET XACT_ABORT ON;

/* --- 1) Rocni vnos kontaktov ------------------------------------------------------------ */

IF OBJECT_ID(N'pim.CustomerContact', N'U') IS NULL
BEGIN
  CREATE TABLE pim.CustomerContact
  (
    CustomerContactId bigint IDENTITY(1,1) NOT NULL,
    OrganizationId int NOT NULL,
    CustomerId bigint NOT NULL,
    /* Vse stiri vrednosti so lahko prazne: prazna pomeni »rocnega prepisa ni«,
       ne »kontakta ni«. Ucinkovita vrednost je rocni prepis, sicer izvor. */
    Email nvarchar(400) NULL,
    Phone nvarchar(200) NULL,
    Mobile nvarchar(200) NULL,
    /* Vec oseb iste stranke gre v eno celico, loceno z ' | ' — tako jih pricakuje
       izvoz za Magento in tako jih je zlagal stari sistem. */
    Persons nvarchar(1000) NULL,
    UpdatedBy nvarchar(200) NOT NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_CustomerContact_UpdatedUtc DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_CustomerContact PRIMARY KEY CLUSTERED (CustomerContactId),
    CONSTRAINT FK_CustomerContact_Customer FOREIGN KEY (CustomerId) REFERENCES b2b.Customer (CustomerId),
    CONSTRAINT UQ_CustomerContact UNIQUE (OrganizationId, CustomerId)
  );
END;

/* --- 2) Pisanje rocnega prepisa --------------------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE b2b.SaveCustomerContact
  @OrganizationId int,
  @CustomerId bigint,
  @Email nvarchar(400) = NULL,
  @Phone nvarchar(200) = NULL,
  @Mobile nvarchar(200) = NULL,
  @Persons nvarchar(1000) = NULL,
  @ChangedBy nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  BEGIN TRAN;

  IF NOT EXISTS (SELECT 1 FROM b2b.Customer WHERE CustomerId = @CustomerId AND OrganizationId = @OrganizationId)
    THROW 52000, N''Stranka ne obstaja.'', 1;

  SET @Email = NULLIF(LTRIM(RTRIM(@Email)), N'''');
  SET @Phone = NULLIF(LTRIM(RTRIM(@Phone)), N'''');
  SET @Mobile = NULLIF(LTRIM(RTRIM(@Mobile)), N'''');
  SET @Persons = NULLIF(LTRIM(RTRIM(@Persons)), N'''');

  /* Vrednosti iz zajema. Danes so vse NULL, ker zajema kontaktov ni (migracija 140, uvod).
     Ko endpoint GetCustomerContacts dobi svojo entiteto in preslikavo, se napolnijo tu —
     na enem mestu, in spodnje pravilo takoj velja. */
  DECLARE @SourceEmail nvarchar(400) = NULL,
          @SourcePhone nvarchar(200) = NULL,
          @SourceMobile nvarchar(200) = NULL,
          @SourcePersons nvarchar(1000) = NULL;

  /* Rocna vrednost, enaka izvoru, ni prepis. Brez tega bi krog izvoz -> uvoz posnetek
     izvora zabetoniral kot rocno vrednost in izvor ne bi mogel vec nicesar popraviti. */
  IF @SourceEmail IS NOT NULL AND @Email = @SourceEmail SET @Email = NULL;
  IF @SourcePhone IS NOT NULL AND @Phone = @SourcePhone SET @Phone = NULL;
  IF @SourceMobile IS NOT NULL AND @Mobile = @SourceMobile SET @Mobile = NULL;
  IF @SourcePersons IS NOT NULL AND @Persons = @SourcePersons SET @Persons = NULL;

  DECLARE @old nvarchar(max) =
    (SELECT * FROM pim.CustomerContact WHERE OrganizationId = @OrganizationId AND CustomerId = @CustomerId
     FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

  /* Vrstica ostane tudi, ko so vse stiri vrednosti prazne: to je »pocisti rocni prepis«
     in ne brisanje podatka. Kdo in kdaj je prepis umaknil, se tako se vedno vidi. */
  MERGE pim.CustomerContact AS target
  USING (SELECT @OrganizationId AS OrganizationId, @CustomerId AS CustomerId) AS source
    ON target.OrganizationId = source.OrganizationId AND target.CustomerId = source.CustomerId
  WHEN MATCHED THEN UPDATE SET
    Email = @Email, Phone = @Phone, Mobile = @Mobile, Persons = @Persons,
    UpdatedBy = @ChangedBy, UpdatedUtc = SYSUTCDATETIME()
  WHEN NOT MATCHED THEN
    INSERT (OrganizationId, CustomerId, Email, Phone, Mobile, Persons, UpdatedBy)
    VALUES (@OrganizationId, @CustomerId, @Email, @Phone, @Mobile, @Persons, @ChangedBy);

  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy)
  SELECT @OrganizationId, N''CustomerContact'', CONVERT(nvarchar(200), @CustomerId), N''UPSERT'', @old,
    (SELECT * FROM pim.CustomerContact WHERE OrganizationId = @OrganizationId AND CustomerId = @CustomerId
     FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
    @ChangedBy;

  COMMIT;
END;');

/* --- 3) Kartica stranke dobi osmi nabor: kontakti --------------------------------------- */
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

  /* 1 — splosni podatki: kar je prislo iz SAOP, in profil, ki je last PIM. */
  SELECT customer.CustomerId, customer.CustomerKey, customer.Name,
    customer.PayerCode, customer.PayerName, customer.PriceListCode, customer.DiscountPriceListCode,
    customer.Address, customer.Street, customer.HouseNumber, customer.City, customer.PostalCode,
    customer.Country, customer.TaxNumber, customer.RegistrationNumber, customer.ActivityCode,
    customer.SubjectToVat, customer.PaymentDays, customer.RebatePercent, customer.IsActive,
    customer.CustomerType AS SourceCustomerType, customer.LegalForm, customer.IsDefaulter,
    customer.UpfrontPayment, customer.LanguageId, customer.CurrencyCode, customer.UpdatedUtc,
    profileValue.CustomerTypeCode, profileValue.CustomerKind, profileValue.PayerKind,
    PackagingDiscountEnabled = COALESCE(profileValue.PackagingDiscountEnabled, CONVERT(bit, 0)),
    ValueDiscountEnabled = COALESCE(profileValue.ValueDiscountEnabled, CONVERT(bit, 0)),
    B2bPlusEnabled = COALESCE(profileValue.B2bPlusEnabled, CONVERT(bit, 0)),
    profileValue.B2bPlusValidFrom, profileValue.B2bPlusValidTo,
    WebEnabled = COALESCE(profileValue.WebEnabled, CONVERT(bit, 0)),
    MagentoGroupKey = magentoGroup.MagentoGroupKey,
    CustomerTypeName = typeCatalog.Name
  FROM b2b.Customer AS customer
  LEFT JOIN pim.CustomerWebProfile AS profileValue ON profileValue.CustomerId = customer.CustomerId
  LEFT JOIN pim.CustomerTypeCatalog AS typeCatalog ON typeCatalog.CustomerTypeCode = profileValue.CustomerTypeCode
  LEFT JOIN pim.CustomerTypeMagentoGroup AS magentoGroup
    ON magentoGroup.CustomerTypeCode = profileValue.CustomerTypeCode AND magentoGroup.IsActive = 1
  WHERE customer.OrganizationId = @OrganizationId AND customer.CustomerId = @CustomerId;

  /* 2 — skupine popustov po skupini artiklov. Nosilna vez je skupina strank (pravila §4.1),
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

  /* 3 — vrednostni pragovi stranke. */
  SELECT tier.TierNumber, tier.ThresholdGrossExVat, tier.PercentValue, tier.IsActive
  FROM pim.CustomerValueDiscountTier AS tier
  WHERE tier.CustomerId = @CustomerId
  ORDER BY tier.TierNumber;

  /* 4 — posebni popusti za stranko na posameznem izdelku. */
  SELECT overrideValue.OverrideId, overrideValue.DiscountCode, overrideValue.ValidFrom,
    overrideValue.ValidTo, overrideValue.IsActive,
    ItemID = product.ItemID, ProductName = product.ItemID
  FROM b2b.CustomerPackagingDiscountOverride AS overrideValue
  LEFT JOIN pim.Product AS product ON product.PimProductId = overrideValue.PimProductId
  WHERE overrideValue.CustomerId = @CustomerId
  ORDER BY overrideValue.OverrideId DESC;

  /* 5 — poslovne enote in tranziti. */
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

  /* 6 — zaznamki, najnovejsi zgoraj. */
  SELECT note.CustomerNoteId, note.Body, note.CreatedBy, note.CreatedUtc
  FROM pim.CustomerNote AS note
  WHERE note.OrganizationId = @OrganizationId AND note.CustomerId = @CustomerId
  ORDER BY note.CreatedUtc DESC, note.CustomerNoteId DESC;

  /* 7 — zgodovina sprememb iz obstojece revizijske sledi; nove tabele ni. */
  SELECT auditValue.AuditLogId, auditValue.EntityType, auditValue.ActionCode,
    auditValue.OldValueJson, auditValue.NewValueJson, auditValue.ChangedBy, auditValue.ChangedUtc
  FROM b2b.AuditLog AS auditValue
  WHERE auditValue.OrganizationId = @OrganizationId
    AND auditValue.EntityKey IN (CONVERT(nvarchar(200), @CustomerId), @CustomerKey)
  ORDER BY auditValue.ChangedUtc DESC, auditValue.AuditLogId DESC;

  /* 8 — kontakti. Ucinkovita vrednost je rocni prepis, sicer izvor; znacka pove, kateri
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
END;');

/* --- 4) Varovalke ----------------------------------------------------------------------- */

IF OBJECT_ID(N'pim.CustomerContact', N'U') IS NULL
  THROW 52950, 'Tabele pim.CustomerContact ni.', 1;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_CustomerContact' AND object_id = OBJECT_ID(N'pim.CustomerContact'))
  THROW 52951, 'Kontakti niso enolicni po podjetju in stranki.', 1;

IF OBJECT_ID(N'b2b.SaveCustomerContact', N'P') IS NULL
  THROW 52952, 'Procedure b2b.SaveCustomerContact ni.', 1;

IF OBJECT_ID(N'intranet.GetCustomerCard', N'P') IS NULL
  THROW 52953, 'Procedure intranet.GetCustomerCard ni.', 1;

/*
  T-SQL ne zna presteti naborov tuje procedure — INSERT ... EXEC zajame samo prvega,
  sys.dm_exec_describe_first_result_set pa po imenu samo prvega. Zato migracija preveri
  besedilo prevedene procedure: osmi nabor mora biti v njej in mora stati ZA sedmim.
  Dejansko stetje osmih naborov prek SqlDataReader.NextResult je v testu
  PIM.F10.CustomersUxTests, kjer je to mogoce dokazati.
*/
DECLARE @cardDefinition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetCustomerCard'));

IF @cardDefinition IS NULL OR CHARINDEX(N'PersonsSource', @cardDefinition) = 0
  THROW 52954, 'intranet.GetCustomerCard nima nabora s kontakti.', 1;

IF CHARINDEX(N'pim.CustomerContact', @cardDefinition) < CHARINDEX(N'b2b.AuditLog AS auditValue', @cardDefinition)
  THROW 52955, 'Nabor s kontakti mora stati za zgodovino sprememb, sicer se obstojeca branja premaknejo.', 1;

IF CHARINDEX(N'SourceNote', @cardDefinition) = 0 OR CHARINDEX(N'SourceAvailable', @cardDefinition) = 0
  THROW 52956, 'Kartica mora povedati, ali izvor kontaktov obstaja, in kaj manjka, kadar ga ni.', 1;

/*
  Pravilo »rocna vrednost, enaka izvoru, se ne shrani kot prepis« mora biti v proceduri,
  ne v vmesniku: vmesnikov je vec, procedura je ena.
*/
IF CHARINDEX(N'@SourceEmail', OBJECT_DEFINITION(OBJECT_ID(N'b2b.SaveCustomerContact'))) = 0
  THROW 52957, 'Pisljiva pot ne pozna primerjave z izvorom.', 1;
